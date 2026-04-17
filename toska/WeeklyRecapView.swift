import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct WeeklyRecapView: View {
    @Environment(\.dismiss) var dismiss
    @State private var postCount = 0
    @State private var totalLikesReceived = 0
    @State private var topTag: String? = nil
    @State private var topPostText = ""
    @State private var topPostLikes = 0
    @State private var communityPostCount = 0
    @State private var isLoading = true
    @State private var isVisible = false
    
    var body: some View {
        ZStack {
            Color(hex: "0a0908").ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                            .frame(width: 32, height: 32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                Spacer()
                
                if isLoading {
                                    ProgressView().tint(Color.toskaBlue)
                                } else if postCount == 0 {
                                    VStack(spacing: 12) {
                                        Text("nothing this week.")
                                            .font(.custom("Georgia-Italic", size: 20))
                                            .foregroundColor(.white.opacity(0.4))
                                        Text("say something. it keeps.")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.2))
                                    }
                                    .opacity(isVisible ? 1 : 0)
                                    .animation(.easeIn(duration: 0.8).delay(0.3), value: isVisible)
                                } else {
                                    VStack(spacing: 24) {                        VStack(spacing: 4) {
                            Text("your week")
                                                            .font(.custom("Georgia-Italic", size: 22))
                                                            .foregroundColor(.white)
                            Text(weekRangeString())
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.25))
                        }
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.6).delay(0.2), value: isVisible)
                        
                        // Stats row
                        HStack(spacing: 24) {
                            recapStat(number: postCount, label: "posts")
                            recapStat(number: totalLikesReceived, label: "total likes")
                        }
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.6).delay(0.5), value: isVisible)
                        
                        // Top post
                        if !topPostText.isEmpty {
                            VStack(spacing: 8) {
                                Text("hit the hardest this week")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color.toskaBlue)
                                    .tracking(1)
                                
                                Text(topPostText)
                                    .font(.custom("Georgia", size: 16))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineSpacing(5)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                                
                                Text("\(formatCount(topPostLikes)) felt this")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "c47a8a").opacity(0.7))
                            }
                            .opacity(isVisible ? 1 : 0)
                            .offset(y: isVisible ? 0 : 15)
                            .animation(.easeOut(duration: 0.8).delay(0.8), value: isVisible)
                        }
                        
                        // Top mood
                        if let tag = topTag {
                            VStack(spacing: 4) {
                                Text("you were mostly feeling")
                                                                    .font(.system(size: 9))
                                                                    .foregroundColor(.white.opacity(0.3))
                                Text(tag)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(tagColor(for: tag))
                            }
                            .opacity(isVisible ? 1 : 0)
                            .animation(.easeIn(duration: 0.6).delay(1.1), value: isVisible)
                        }
                        
                        // Community stat
                        if communityPostCount > 0 {
                            Text("\(formatCount(communityPostCount)) people said something they couldnt say anywhere else this week")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.25))
                                .opacity(isVisible ? 1 : 0)
                                .animation(.easeIn(duration: 0.6).delay(1.4), value: isVisible)
                        }
                    }
                }
                
                Spacer()
                
                // Share button
                // Share button — hidden while loading so it can't be tapped
                              // before data has arrived (would share zeros).
                              if !isLoading {
                                  Button {
                                      shareRecap()
                                  } label: {
                                      HStack(spacing: 6) {
                                          Image(systemName: "square.and.arrow.up")
                                              .font(.system(size: 12))
                                          Text("share recap")
                                              .font(.system(size: 12, weight: .medium))
                                      }
                                      .foregroundColor(Color.toskaBlue)
                                      .padding(.horizontal, 24)
                                      .padding(.vertical, 10)
                                      .background(Color.toskaBlue.opacity(0.1))
                                      .cornerRadius(20)
                                  }
                                  .opacity(isVisible ? 1 : 0)
                                  .animation(.easeIn(duration: 0.6).delay(1.7), value: isVisible)
                              }
                Text("toska")
                    .font(.custom("Georgia-Italic", size: 13))
                    .foregroundColor(.white.opacity(0.12))
                    .padding(.top, 12)
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
                    fetchRecapData()
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        isVisible = true
                    }
                }
    }
    
    func recapStat(number: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(number)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
    }
    
    func weekRangeString() -> String {
        let calendar = Calendar.current
        let today = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: weekAgo).lowercased()) – \(formatter.string(from: today).lowercased())"
    }
    
    func fetchRecapData() {
            guard let uid = Auth.auth().currentUser?.uid else {
                isLoading = false
                return
            }
            let db = Firestore.firestore()
            // Anchor to start-of-day in the user's calendar so the window is a
            // full 7 calendar days regardless of when the user opens the recap.
            // Using addingTimeInterval(-7*86400) would drift up to 23-25h around DST.
            let calendar = Calendar.current
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date())) ?? Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let userWeekQuery = db.collection("posts")
                .whereField("authorId", isEqualTo: uid)
                .whereField("createdAt", isGreaterThan: Timestamp(date: weekAgo))
            
            Task { @MainActor in
                // Run all four queries concurrently, wait for all to finish
                async let postCountResult: Int = {
                    let snap = try? await userWeekQuery.count.getAggregation(source: .server)
                    return Int(truncating: snap?.count ?? 0)
                }()
                
                async let communityCountResult: Int = {
                                    let snap = try? await db.collection("posts")
                                        .whereField("createdAt", isGreaterThan: Timestamp(date: weekAgo))
                                        .whereField("isRepost", isEqualTo: false)
                                        .count
                                        .getAggregation(source: .server)
                                    return Int(truncating: snap?.count ?? 0)
                                }()
                
                async let topPostResult: (String, Int) = {
                    let snap = try? await userWeekQuery
                        .order(by: "likeCount", descending: true)
                        .limit(to: 1)
                        .getDocuments()
                    if let doc = snap?.documents.first {
                        let data = doc.data()
                        return (data["text"] as? String ?? "", data["likeCount"] as? Int ?? 0)
                    }
                    return ("", 0)
                }()
                
                async let tagDistResult: (Int, String?) = {
                    let snap = try? await userWeekQuery
                        .order(by: "createdAt", descending: true)
                        .limit(to: 100)
                        .getDocuments()
                    guard let docs = snap?.documents else { return (0, nil) }
                    var likes = 0
                    var tagCounts: [String: Int] = [:]
                    for doc in docs {
                        let data = doc.data()
                        likes += data["likeCount"] as? Int ?? 0
                        if let tag = data["tag"] as? String {
                            tagCounts[tag, default: 0] += 1
                        }
                    }
                    return (likes, tagCounts.max(by: { $0.value < $1.value })?.key)
                }()
                
                // Await all four — none can leave isLoading stuck
                self.postCount = await postCountResult
                self.communityPostCount = await communityCountResult
                let (topText, topLikes) = await topPostResult
                self.topPostText = topText
                self.topPostLikes = topLikes
                let (totalLikes, tag) = await tagDistResult
                self.totalLikesReceived = totalLikes
                self.topTag = tag
                
                self.isLoading = false
            }
        }
    
    @MainActor
    func shareRecap() {
        let cardView = ZStack {
            Color(hex: "0a0908")
            VStack(spacing: 16) {
                Spacer()
                Text("my week")
                                    .font(.custom("Georgia-Italic", size: 20))
                                    .foregroundColor(.white)
                Text(weekRangeString())
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.25))
                Spacer()
                HStack(spacing: 24) {
                    recapStat(number: postCount, label: "posts")
                    recapStat(number: totalLikesReceived, label: "total likes")
                }
                if let tag = topTag {
                    Text("mostly \(tag)")
                        .font(.system(size: 11))
                        .foregroundColor(tagColor(for: tag).opacity(0.7))
                }
                Spacer()
                Text("toska")
                    .font(.custom("Georgia-Italic", size: 12))
                    .foregroundColor(.white.opacity(0.12))
                    .padding(.bottom, 16)
            }
        }
            .frame(width: 390, height: 690)
                    .environment(\.colorScheme, .dark)
                    
                    let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0
        if let image = renderer.uiImage {
                            presentShareSheet(with: [image])
                        }
            }
        }
